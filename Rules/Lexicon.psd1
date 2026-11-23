# Rules/Lexicon.psd1 - the document category lexicon (v3.0 Phase 2.6; extended v3.0.1 B4).
#
# Weighted token scoring for DOCUMENTS (pdf/docx/txt/md/csv/...). A file's stem,
# its metadata (title/creator) and its first 2 KB text snippet are matched against
# the entries below; the score becomes the Decision's confidence.
#   Filename tokens  count at 2.0x weight each (the strongest single signal)
#   Metadata tokens  count at 1.5x weight each (title / creator)
#   Content tokens   count at 0.8x weight each (first 2 KB of text)
# confidence = matched / (matched + Confidence.Divider)
# The per-source breakdown is returned alongside the confidence and is LOGGED in
# the -Explain output (v3.0.1 B4: separate, logged weights).
# Entries are evaluated in order; the best match wins, ties break by list order
# (deterministic). Work is deliberately evaluated BEFORE Education so a report-
# bearing NGO document ('Workshop Report') is a programme document, while bare
# training/curriculum names stay Education (they carry no Work token). Extend freely - multilingual tokens are welcome (Swahili and
# Kenyan administrative terms are included as examples).
#
# v3.0.1 B4 additions: monitoring & evaluation and NGO programme vocabulary
# (MEAL, M&E, narrative report, monthly/quarterly report, proposal, concept note,
# supervision, workplan, logframe, indicator, baseline, endline, training,
# workshop, curriculum, minutes, TOR / terms of reference, MoU, budget) and
# CV/bio/profile terms, mapped to Documents\Work, Documents\Education,
# Documents\Legal-Identity and Documents\Personal.

@{
    Version = '1.1'

    Multiplier = @{ Filename = 2.0; Metadata = 1.5; Content = 0.8 }

    Confidence = @{ Divider = 1.5 }     # matched/(matched+1.5): 3.5 -> 0.70, 1.0 -> 0.40

    Entries = @(
        @{ Subtype = 'Finance\Invoices'
           Filename = @('invoice','ankara')
           Content  = @('invoice','invoice number','invoice no','amount due','total due','payment due','due date','bill to','tax invoice','vat amount') }

        @{ Subtype = 'Finance\Receipts'
           Filename = @('receipt','risiti')
           Content  = @('receipt','received from','amount received','paid by','cash received','mpesa','m-pesa','transaction id','thank you for your payment') }

        @{ Subtype = 'Finance\Statements'
           Filename = @('statement','bank statement','mpesa statement','m-pesa statement')
           Content  = @('statement of account','account statement','opening balance','closing balance','balance brought forward','transaction history','debit','credit') }

        @{ Subtype = 'Finance\Tax'
           Filename = @('tax','paye','kra','vat return','nhif','nssf','withholding','it1','p9 form')
           Content  = @('kenya revenue authority','kra','pin number','tax payer','paye','vat','withholding tax','tax return','assessment','nhif','nssf','itax') }

        @{ Subtype = 'Legal-Identity'
           Filename = @('contract','agreement','certificate','passport','identity','id scan','deed','licence','license','permit','lease')
           Content  = @('this agreement','the parties','witnesseth','hereby','terms and conditions','certificate of','certificate','passport number','identity card','national id','date of birth','signature','in witness whereof') }

        @{ Subtype = 'Work'
           Filename = @('proposal','minutes','memo','report','brief','agenda','meeting',
                        'meal','m&e','narrative report','monthly report','quarterly report',
                        'concept note','supervision','workplan','logframe','tor','terms of reference','mou','budget')
           Content  = @('meeting minutes','action items','agenda','attendees','proposal','project plan','deliverables','milestones','q1','q2','stakeholders','follow up','as discussed',
                        'meal','m&e','logframe','indicator','baseline','endline','workplan','supervision','monitoring and evaluation','narrative report','monthly report','quarterly report','concept note','terms of reference','mou','memorandum of understanding','budget','donor','programme','project','beneficiaries','activity report','field visit') }

        @{ Subtype = 'Education'
           Filename = @('thesis','dissertation','syllabus','assignment','coursework','exam','lecture','timetable','transcript','training','curriculum','workshop','scheme of work','lesson plan')
           Content  = @('university','school','college','campus','faculty','department of','course outline','learning outcomes','semester','assignment','examination','thesis','references','bibliography','chapter one','introduction','training','curriculum','facilitator','participants','capacity building') }

        @{ Subtype = 'Personal'
           Filename = @('cv','resume','bio','biodata','profile','curriculum vitae')
           Content  = @('curriculum vitae','personal profile','resume','date of birth','references available','work experience','professional experience','skills','hobbies','marital status','nationality') }

        @{ Subtype = 'Manuals'
           Filename = @('manual','handbook','user guide','quick start','instructions','guide')
           Content  = @('user manual','quick start','installation guide','step 1','step 2','troubleshooting','features','specifications','warranty','safety instructions','table of contents','getting started') }

        @{ Subtype = 'Books'
           Filename = @('book','novel','textbook','anthology')
           Content  = @('chapter','copyright','published by','isbn','all rights reserved','preface','foreword','contents','epilogue','prologue') }
    )
}
